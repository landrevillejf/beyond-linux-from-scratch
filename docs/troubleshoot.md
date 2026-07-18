# Troubleshooting

## Build fails at a stage

Check `lfs-output/logs/<stage>.log` for the exact failure and resume with:

```bash
python3 builder.py --resume-from <stage-name>
```

## Missing host tools

Install the required host dependencies (`bash`, `gcc`, `make`, `tar`, `xorriso`, etc.) then rerun.

## Outdated or missing sources

If official URLs are stale, provide `packages/custom-sources.list` with working mirrors and regenerate/download sources.

## Release workflow failures

When CI fails, inspect the failing step logs first (tests, docs build, or release stage), then re-run after fixing only that surface.

## Useful references

- [Overview](content.md)
- [LPM Package Manager](lpm.md)
- [Testing How-To](testing-howto.md)
