# FAQ

> [!IMPORTANT]
> This file contains documentation for the CURRENT BRANCH. To find documentation for official releases, find the target release on the [Release Page](https://github.com/apple/container/releases) and click the tag corresponding to your release version.
>
> Example: [release 0.4.1 tag](https://github.com/apple/container/tree/0.4.1)

## Why do files under Application Support look enormous?

`container` keeps Linux disk images (including builder `initfs`/`rootfs` and snapshot files) under `~/Library/Application Support/com.apple.container`. Those images are sparse files: Finder and some tools report the apparent size (often hundreds of gigabytes or more), not the much smaller amount of space actually allocated on disk.

To inspect on-disk usage, use:

```bash
du -h ~/Library/Application\ Support/com.apple.container
ls -lhs ~/Library/Application\ Support/com.apple.container
```

## Time Machine backups hang or grow unexpectedly

Some Time Machine destinations have trouble with these sparse files. Backups may stall for a long time, or the files may expand toward their full apparent size on the backup volume (this is especially common with HFS+ destinations, and has also been reported with some APFS and network backups).

If Time Machine gets stuck on `container` data, exclude the application support directory:

```bash
sudo tmutil addexclusion -p ~/Library/Application\ Support/com.apple.container
```

That directory is recreated as needed when missing, so excluding it from Time Machine is a safe workaround. If you need durable copies of images, use `container image save` instead of relying on Time Machine for this path.
