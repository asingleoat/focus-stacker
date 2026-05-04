# Oracle And Reference Tools

Files in this directory are not part of the clean "original Zig implementation"
bucket used by the main application.

They exist to compare behavior against upstream implementations, dump upstream
pyramid levels, and validate parity during porting work.

Some of these tools assume the optional local `upstream/` reference tree has
been populated with:

```sh
./scripts/fetch_upstream_refs.sh
```

In this repository they are licensed under GPL-3.0-only as a separate
reference/oracle tooling bucket. That separation is intentional:

- it keeps the main Zig implementation bucket easy to identify
- it keeps upstream-facing helper code out of the future relicensing decision
  surface for the core application

Current files:

- `enfuse_pyramid_oracle.cpp`
- `vigra_oracle.cpp`
- `hugin_config.h`
