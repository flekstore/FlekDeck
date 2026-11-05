#import "unarchive.h"

#include "archive.h"
#include "archive_entry.h"

// libarchive hands data back a block at a time, tens of kilobytes each, and every
// change to the progress is observed and passed on to the main thread. So the
// bytes are counted in `unreported` and reported once they reach `step`.
static int
copy_data(struct archive *ar, struct archive *aw, NSProgress *progress, int64_t step, int64_t *unreported)
{
  int r;
  const void *buff;
  size_t size;
  la_int64_t offset;

  for (;;) {
    r = archive_read_data_block(ar, &buff, &size, &offset);
    if (r == ARCHIVE_EOF)
      return (ARCHIVE_OK);
    if (r < ARCHIVE_OK)
      return (r);
    r = archive_write_data_block(aw, buff, size, offset);
    if (r < ARCHIVE_OK) {
      fprintf(stderr, "%s\n", archive_error_string(aw));
      return (r);
    }
    *unreported += size;
    if (*unreported >= step) {
      progress.completedUnitCount += *unreported;
      *unreported = 0;
    }
  }
}

int extract(NSString* fileToExtract, NSString* extractionPath, NSProgress* progress)
{
    struct archive *a;
    struct archive *ext;
    struct archive_entry *entry;
    int flags;
    int r;

    /* Select which attributes we want to restore. */
    flags = ARCHIVE_EXTRACT_TIME;
    flags |= ARCHIVE_EXTRACT_PERM;
    flags |= ARCHIVE_EXTRACT_ACL;
    flags |= ARCHIVE_EXTRACT_FFLAGS;

    // Calculate decompressed size
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return 1;
    }
    int64_t totalSize = 0;
    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN) {
            archive_read_close(a);
            archive_read_free(a);
            return 1;
        }
        totalSize += archive_entry_size(entry);
    }
    archive_read_close(a);
    archive_read_free(a);
    // Set once rather than per entry, for the same reason copy_data reports in
    // steps. About 200 of them: finer than any bar draws the extraction.
    progress.totalUnitCount += totalSize;
    int64_t step = MAX(totalSize / 200, 1);
    int64_t unreported = 0;

    // Re-open the archive and extract
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return 1;
    }
    ext = archive_write_disk_new();
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);

    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r == ARCHIVE_EOF)
            break;
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN)
            break;
        
        NSString* currentFile = [NSString stringWithUTF8String:archive_entry_pathname(entry)];
        NSString* fullOutputPath = [extractionPath stringByAppendingPathComponent:currentFile];
        //printf("extracting %@ to %@\n", currentFile, fullOutputPath);
        archive_entry_set_pathname(entry, fullOutputPath.fileSystemRepresentation);
        
        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
        else if (archive_entry_size(entry) > 0) {
            r = copy_data(a, ext, progress, step, &unreported);
            if (r < ARCHIVE_OK)
                fprintf(stderr, "%s\n", archive_error_string(ext));
            if (r < ARCHIVE_WARN)
                break;
        }
        r = archive_write_finish_entry(ext);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
        if (r < ARCHIVE_WARN)
            break;
    }
    if (unreported > 0)
        progress.completedUnitCount += unreported;
    archive_read_close(a);
    archive_read_free(a);
    archive_write_close(ext);
    archive_write_free(ext);
    
    return 0;
}
