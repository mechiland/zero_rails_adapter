# Next.js integration fixture

This fixture shows the generated client half of Rails-backed generic CRUD.
Install the current `@rocicorp/zero` and `zod` releases in a Next.js app, or
generate equivalent files directly from the Rails models:

```sh
bin/rails generate zero_rails_adapter:typescript ../web/src/zero
```

Register the exported `schema` and `mutators` with the app's Zero client.

Configure:

```env
NEXT_PUBLIC_ZERO_CACHE_URL=http://localhost:4848
NEXT_PUBLIC_ZERO_MUTATE_URL=http://localhost:3000/zero/mutate
```

Configure zero-cache with the same Rails URL:

```sh
ZERO_MUTATE_URL=http://localhost:3000/zero/mutate
ZERO_MUTATE_API_KEY=development-secret
```

The Rails application must mount the Engine at `/zero`, use the generated API
key verifier, publish explicit `Book` columns through
`config.published_schema`, and opt `Book` into
`config.crud_model_provider`. No Ruby mutator class is needed for
`books.create/update/destroy`.
