import {createSchema, number, string, table} from '@rocicorp/zero'

const books = table('books')
  .columns({
    id: string(),
    title: string(),
    owner_id: string(),
    created_at: number(),
    updated_at: number(),
  })
  .primaryKey('id')

export const schema = createSchema({tables: [books]})
export type Schema = typeof schema

declare module '@rocicorp/zero' {
  interface DefaultTypes {
    schema: Schema
  }
}
