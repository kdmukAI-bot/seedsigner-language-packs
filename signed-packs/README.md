# signed-packs/

The **deliverable**. Each `signed-packs/<locale>/` is a reproducibly-built pack
that an **offline signer** has verified and signed, then committed **by hand** —
per-locale, at its own cadence.

**Nothing automated ever writes here.** CI never signs and never commits; dev
builds go to the gitignored `build/`. The signing key never touches CI.

Each signed pack carries a **content hash of the unsigned bytes**, enabling two
independent checks:

1. **Content integrity (keyless):** anyone rebuilds the pack from the pinned
   inputs (`scripts/build_packs.sh`), hashes it, and compares to the embedded
   content hash. No key required.
2. **Authenticity:** verify the signature over that hash against the public key.
   On-device, the (future) secure bootloader does this via the `ss_pack_provider`
   chokepoint.

Consumers **copy** `signed-packs/<locale>/` into their runtime path
(`src/lang-packs`, `/sd`); the pinned version is the git ref / release tag.

> The exact signing scheme (algorithm, key management, content-hash format,
> bootloader path) is still an **open sub-design** — see the repo README's
> "Signing (deferred)" section. Until it lands, this directory stays empty and
> no packs are committed.
