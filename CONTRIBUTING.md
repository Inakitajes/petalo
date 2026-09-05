# Contributing

Thanks for helping improve Petalo.

## Development setup

Requirements:

- macOS 14 or newer;
- Swift 6.0 or newer.

```bash
swift build
swift run petalo-tests
./scripts/build-app.sh
open .build/Petalo.app
```

## Workflow

1. Add a failing behavioral test for every runtime change.
2. Implement the smallest complete change.
3. Run the full build, behavioral tests, and app-bundle build.
4. Update documentation when behavior, permissions, or privacy change.

Keep product-specific state, integrations, and automation out of the reusable UI foundation unless the product direction explicitly changes. Pull requests must not contain credentials, generated `.app` bundles, signing material, or unrelated formatting churn.
