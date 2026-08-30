## What does this change?

## Why?

## How was it verified?

<!-- Every claim in this repo is meant to be reproducible. Paste the commands
     and the relevant output. -->

```
make lint
make test
```

## Checklist

- [ ] `make lint` passes
- [ ] `make test` passes against a live cluster
- [ ] New behaviour is covered by a bats assertion
- [ ] Comments explain *why* a value was chosen, not what the field does
- [ ] Any new claim in `docs/` was actually observed, not assumed
