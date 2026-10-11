<!-- OWNER: AI-01 -->
# third_party/whisper.cpp

whisper.cpp **v1.9.4** (commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`, ggml 0.23.0), pruned to the CPU, Metal
and BLAS backends plus the CMake files our builds need (194 files, 7.77 MiB). Provenance, pruning rules, the
tarball sha256 and the v1.9.5 review are in `VENDORED.md`; licences are in `../LICENSE-THIRD-PARTY.md`.

Do not edit `whisper.cpp/`. To check or redo the vendoring, run from the package root:

    tool/vendor_whisper.sh --check    # download, verify sha256 + commit, diff against the committed tree
    tool/vendor_whisper.sh            # re-create the tree

Models are never bundled; they are downloaded on first use after consent (ARCH §16.2-§16.3). The plugin still
builds without any native library until AI-04/AI-05 wire the CMake builds.
