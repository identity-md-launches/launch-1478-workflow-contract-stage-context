# Vendored dependencies

All files required for compilation and tests are present as ordinary source files; there are no submodules, package installation hooks or external remappings.

| Dependency | Release | Included files | License |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0) | v5.1.0 | Transitive Solidity dependencies of ERC20, SafeERC20, Ownable2Step, ReentrancyGuard and Math | `lib/openzeppelin-contracts/LICENSE` (MIT) |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/v1.9.6) | v1.9.6 | `src/` | `lib/forge-std/LICENSE-MIT`, `LICENSE-APACHE` |

Production sources use the OpenZeppelin dependencies through `remappings.txt`. Tests use forge-std. Production libraries only call internal functions, so no deployed library addresses are needed. Unused helper functions in vendored libraries are not linked into the applications.

`scripts/export_abis.py` uses only Python's standard library and the installed `forge` command. Slither was used as an optional local analysis tool from a temporary environment; it is not part of compilation, tests or the offline verifier. Its version and results are in `SECURITY.md`.
