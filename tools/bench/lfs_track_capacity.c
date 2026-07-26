/*
 * Host regression for the exact nRF52840 InternalFS geometry and bundled LittleFS v1.
 *
 * Compiled/run by verify_track_layout.py against PlatformIO's actual lfs.c. It proves both
 * sides of the storage regression: rewriting byte zero of an 8,016-byte staging file needs
 * a full COW chain and fails once only 2,304 bytes of prefs are present, while appending the
 * 16-byte commit footer succeeds with an 8 KiB prefs reserve.
 */
#include "lfs.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { BLOCK_SIZE = 128, BLOCK_COUNT = 224 };
static uint8_t disk[BLOCK_COUNT][BLOCK_SIZE];

void *pvPortMalloc(size_t size)
{
    return malloc(size);
}

void vPortFree(void *ptr)
{
    free(ptr);
}

static int bdRead(const struct lfs_config *c, lfs_block_t block, lfs_off_t off, void *buffer, lfs_size_t size)
{
    (void)c;
    memcpy(buffer, &disk[block][off], size);
    return 0;
}

static int bdProg(const struct lfs_config *c, lfs_block_t block, lfs_off_t off, const void *buffer, lfs_size_t size)
{
    (void)c;
    const uint8_t *src = buffer;
    for (lfs_size_t i = 0; i < size; i++) {
        if ((disk[block][off + i] & src[i]) != src[i])
            return LFS_ERR_CORRUPT;
        disk[block][off + i] &= src[i];
    }
    return 0;
}

static int bdErase(const struct lfs_config *c, lfs_block_t block)
{
    (void)c;
    memset(disk[block], 0xff, BLOCK_SIZE);
    return 0;
}

static int bdSync(const struct lfs_config *c)
{
    (void)c;
    return 0;
}

static const struct lfs_config cfg = {
    .read = bdRead,
    .prog = bdProg,
    .erase = bdErase,
    .sync = bdSync,
    .read_size = BLOCK_SIZE,
    .prog_size = BLOCK_SIZE,
    .block_size = BLOCK_SIZE,
    .block_count = BLOCK_COUNT,
    .lookahead = 128,
};

static int writeFile(lfs_t *lfs, const char *path, unsigned size)
{
    static uint8_t zeros[256];
    lfs_file_t file;
    int rc = lfs_file_open(lfs, &file, path, LFS_O_RDWR | LFS_O_CREAT | LFS_O_TRUNC);
    if (rc)
        return rc;
    while (size > 0) {
        unsigned n = size < sizeof(zeros) ? size : sizeof(zeros);
        lfs_ssize_t written = lfs_file_write(lfs, &file, zeros, n);
        if (written != (lfs_ssize_t)n) {
            lfs_file_close(lfs, &file);
            return written < 0 ? (int)written : -1000;
        }
        size -= n;
    }
    return lfs_file_close(lfs, &file);
}

static int setup(lfs_t *lfs, unsigned filler, unsigned activeSize)
{
    memset(disk, 0xff, sizeof(disk));
    int rc = lfs_format(lfs, &cfg);
    if (!rc)
        rc = lfs_mount(lfs, &cfg);
    if (!rc)
        rc = lfs_mkdir(lfs, "/prefs");
    if (!rc)
        rc = writeFile(lfs, "/prefs/fill", filler);
    if (!rc)
        rc = writeFile(lfs, "/prefs/simtrk.a", activeSize);
    if (!rc)
        rc = writeFile(lfs, "/prefs/simtrk.b", 8016);
    return rc;
}

static int writeFooter(lfs_t *lfs, int append)
{
    static const uint8_t footer[16] = {'C', 'M', 'I', 'T'};
    lfs_file_t file;
    int flags = LFS_O_RDWR | (append ? LFS_O_APPEND : 0);
    int rc = lfs_file_open(lfs, &file, "/prefs/simtrk.b", flags);
    if (!rc && !append)
        rc = lfs_file_seek(lfs, &file, 0, LFS_SEEK_SET) < 0 ? -1001 : 0;
    if (!rc)
        rc = lfs_file_write(lfs, &file, footer, sizeof(footer)) == (lfs_ssize_t)sizeof(footer) ? 0 : -1002;
    if (!rc)
        rc = lfs_file_close(lfs, &file);
    return rc;
}

static uint8_t seen[BLOCK_COUNT];

static int countBlock(void *unused, lfs_block_t block)
{
    (void)unused;
    if (block < BLOCK_COUNT)
        seen[block] = 1;
    return 0;
}

static unsigned usedBlocks(lfs_t *lfs)
{
    memset(seen, 0, sizeof(seen));
    if (lfs_traverse(lfs, countBlock, NULL))
        return BLOCK_COUNT + 1;
    unsigned count = 0;
    for (unsigned i = 0; i < BLOCK_COUNT; i++)
        count += seen[i] != 0;
    return count;
}

int main(void)
{
    lfs_t lfs;
    int rc = setup(&lfs, 2304, 8016);
    if (rc) {
        fprintf(stderr, "old-layout setup failed unexpectedly: %d\n", rc);
        return 1;
    }
    rc = writeFooter(&lfs, 0);
    lfs_unmount(&lfs);
    if (rc != LFS_ERR_NOSPC) {
        fprintf(stderr, "offset-zero rewrite should reproduce ENOSPC, got %d\n", rc);
        return 1;
    }

    rc = setup(&lfs, 8192, 8032);
    if (rc) {
        fprintf(stderr, "append-layout setup failed: %d\n", rc);
        return 1;
    }
    rc = writeFooter(&lfs, 1);
    struct lfs_info info;
    int statRc = lfs_stat(&lfs, "/prefs/simtrk.b", &info);
    unsigned used = usedBlocks(&lfs);
    lfs_unmount(&lfs);
    if (rc || statRc || info.size != 8032 || used > 210) {
        fprintf(stderr, "append promotion failed: close=%d stat=%d size=%lu used=%u\n", rc, statRc,
                (unsigned long)info.size, used);
        return 1;
    }

    printf("PASS: offset-zero=-ENOSPC; append=OK with 8192-byte prefs reserve (%u/224 blocks used)\n", used);
    return 0;
}
