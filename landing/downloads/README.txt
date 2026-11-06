Internal note (never published: branding/tools/make_dist.sh leaves this folder out).
Release binaries are hosted outside Cloudflare Pages (25 MiB file limit): R2, GitHub Releases
or a VPS. Enable the matching /downloads/* line in ../_redirects or set an absolute "url",
then mark each uploaded file "available": true in ../releases.json. File names must match.
