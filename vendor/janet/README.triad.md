# Janet Vendoring

Triad vendors Janet so the embedded scripting runtime builds against a pinned
interpreter instead of a distro-provided `/usr/include/janet` and `libjanet`.

- Upstream: https://github.com/janet-lang/janet
- Version: 1.41.2
- Source archive: `v1.41.2.tar.gz`
- Generated files: `janet.c` and `janet.h`
- License: see `LICENSE`

`janet.c` was generated from the upstream release with:

```sh
make -C /tmp/janet-1.41.2 build/c/janet.c build/janet.h
```

The `vendor/janet/**` path is marked `linguist-vendored` in `.gitattributes`
so the upstream C interpreter does not dominate GitHub language statistics.
