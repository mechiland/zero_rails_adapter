import {
  createBuilder,
  defineQueries,
  defineQuery,
} from '@rocicorp/zero'
import {schema} from './generated/schema.js'

export const zql = createBuilder(schema)

export const queries = defineQueries({
  contractBooks: {
    all: defineQuery(() =>
      zql.contract_books
        .orderBy('id', 'asc')
        .related('labels'),
    ),
  },
})
