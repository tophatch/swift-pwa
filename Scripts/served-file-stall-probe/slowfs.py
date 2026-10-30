"""A read-only passthrough FUSE mount where one file is slow, the way a file on
a network mount is: every lookup and open of remote.bin waits DELAY seconds,
and every read of it a tenth of that. Everything else passes straight through.

Used by Scripts/verify-served-file-stall-linux.sh (#338), which puts fusepy's
fuse.py on the import path.

    python3 slowfs.py <backing-dir> <mountpoint> <delay-seconds>
"""
import os
import sys
import time

from fuse import FUSE, FuseOSError, Operations

SLOW_NAME = "remote.bin"
STAT_KEYS = ("st_mode", "st_size", "st_mtime", "st_atime", "st_ctime", "st_nlink", "st_uid", "st_gid")


class SlowFile(Operations):
    def __init__(self, root, delay):
        self.root, self.delay = root, delay

    def _path(self, path):
        return os.path.join(self.root, path.lstrip("/"))

    def _wait(self, path, delay):
        if os.path.basename(path) == SLOW_NAME:
            time.sleep(delay)

    def getattr(self, path, fh=None):
        self._wait(path, self.delay)
        try:
            st = os.lstat(self._path(path))
        except OSError as e:
            raise FuseOSError(e.errno)
        return {key: getattr(st, key) for key in STAT_KEYS}

    def readdir(self, path, fh):
        return [".", ".."] + os.listdir(self._path(path))

    def open(self, path, flags):
        self._wait(path, self.delay)
        return os.open(self._path(path), os.O_RDONLY)

    def read(self, path, size, offset, fh):
        self._wait(path, self.delay / 10)
        return os.pread(fh, size, offset)

    def release(self, path, fh):
        os.close(fh)


if __name__ == "__main__":
    backing, mountpoint, delay = sys.argv[1], sys.argv[2], float(sys.argv[3])
    FUSE(SlowFile(backing, delay), mountpoint, foreground=True, ro=True)
