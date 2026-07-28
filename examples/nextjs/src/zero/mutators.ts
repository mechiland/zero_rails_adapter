import {defineMutator, defineMutators} from '@rocicorp/zero'
import {z} from 'zod'

export const mutators = defineMutators({
  books: {
    create: defineMutator(
      z.object({
        id: z.string(),
        title: z.string().min(1).max(200),
        owner_id: z.string(),
      }),
      async ({tx, args}) => {
        const now = Date.now()
        await tx.mutate.books.insert({
          ...args,
          created_at: now,
          updated_at: now,
        })
      },
    ),
    update: defineMutator(
      z.object({
        id: z.string(),
        title: z.string().min(1).max(200).optional(),
      }),
      async ({tx, args}) => {
        await tx.mutate.books.update({...args, updated_at: Date.now()})
      },
    ),
    destroy: defineMutator(
      z.object({id: z.string()}),
      async ({tx, args}) => {
        await tx.mutate.books.delete(args)
      },
    ),
  },
})
