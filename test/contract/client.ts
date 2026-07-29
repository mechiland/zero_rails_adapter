import 'fake-indexeddb/auto'
import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {setTimeout as delay} from 'node:timers/promises'
import {Client as PostgresClient} from 'pg'
import WebSocket from 'ws'
import {Zero} from '@rocicorp/zero'
import {mutators} from './generated/mutators.js'
import {schema} from './generated/schema.js'
import {queries} from './queries.js'

Object.defineProperty(globalThis, 'WebSocket', {
  configurable: true,
  value: WebSocket,
  writable: true,
})
Object.defineProperty(globalThis, 'self', {
  configurable: true,
  value: globalThis,
  writable: true,
})

const cacheURL = requiredEnv('ZERO_CACHE_URL')
const databaseURL = requiredEnv('DATABASE_URL')
const mutationLogPath = requiredEnv('MUTATION_LOG_PATH')
const railsMutateURL = requiredEnv('RAILS_MUTATE_URL')
const apiKey = requiredEnv('ZERO_MUTATE_API_KEY')

const zero = new Zero({
  cacheURL,
  logLevel: 'error',
  mutators,
  schema,
  storageKey: `contract-${Date.now()}`,
  userID: undefined,
})
const database = new PostgresClient({connectionString: databaseURL})

try {
  assert.equal(zero.version, '1.8.0')
  await database.connect()
  assert.deepEqual(await zero.run(queries.contractBooks.all()), [])

  const first = await zero.mutate(
    mutators.contract_books.create({
      id: 'book-1',
      sync_id: 'sync-book-1',
      title: 'First',
    }),
  ).server
  assert.equal(first.type, 'success')
  await waitForRows(1)

  const captured = await waitForCapturedMutation('book-1')
  const replayResponse = await fetch(`${railsMutateURL}${captured.path}`, {
    body: JSON.stringify(captured.body),
    headers: {
      'content-type': 'application/json',
      'x-api-key': apiKey,
    },
    method: 'POST',
  })
  assert.equal(replayResponse.status, 200)
  const replay = await replayResponse.json() as {
    mutations: Array<{result: {error?: string}}>
  }
  assert.equal(replay.mutations[0]?.result.error, 'alreadyProcessed')

  const failed = await zero.mutate(
    mutators.contract_books.create({
      id: 'book-invalid',
      sync_id: 'sync-book-invalid',
      title: '',
    }),
  ).server
  assert.equal(failed.type, 'error')
  if (failed.type === 'error') {
    assert.equal(failed.error.type, 'app')
  }

  const third = await zero.mutate(
    mutators.contract_books.create({
      id: 'book-2',
      sync_id: 'sync-book-2',
      title: 'After failure',
    }),
  ).server
  assert.equal(third.type, 'success')

  const rows = await waitForRows(2)
  assert.deepEqual(
    rows.map(row => [
      row.id,
      row.sync_id,
      row.title,
      row.labels.map(label => label.name),
    ]),
    [
      ['book-1', 'sync-book-1', 'First', ['Label First']],
      ['book-2', 'sync-book-2', 'After failure', ['Label After failure']],
    ],
  )

  const clientID = zero.clientID
  await eventually(async () => {
    const result = await database.query<{
      lastMutationID: string
    }>(
      'SELECT "lastMutationID" FROM "contract_0"."clients" WHERE "clientID" = $1',
      [clientID],
    )
    return Number(result.rows[0]?.lastMutationID) === 3
  }, 'LMID did not advance through the failed mutation')

  await eventually(async () => {
    const result = await database.query<{count: string}>(
      'SELECT count(*) FROM "contract_0"."mutations" WHERE "clientID" = $1',
      [clientID],
    )
    return Number(result.rows[0]?.count) === 0
  }, 'acknowledged mutation results were not cleaned up')

  await eventually(async () => {
    const entries = await capturedRequests()
    return entries.some(entry =>
      entry.body.mutations.some(mutation =>
        mutation.name === '_zero_cleanupResults'
      ),
    )
  }, 'zero-cache did not send _zero_cleanupResults')

  const count = await database.query<{count: string}>(
    'SELECT count(*) FROM contract_books',
  )
  assert.equal(Number(count.rows[0]?.count), 2)
  const relatedCounts = await database.query<{
    labels: string
    links: string
  }>(
    'SELECT ' +
      '(SELECT count(*) FROM contract_labels) AS labels, ' +
      '(SELECT count(*) FROM contract_book_labels) AS links',
  )
  assert.equal(Number(relatedCounts.rows[0]?.labels), 2)
  assert.equal(Number(relatedCounts.rows[0]?.links), 2)
  console.log(
    'Zero 1.8 schema, Zero key, relationship, mutation, replication, ' +
      'query, LMID, retry, and cleanup contract passed',
  )
} finally {
  await zero.close()
  await database.end()
}

type CapturedRequest = {
  body: {
    mutations: Array<{
      args: unknown[]
      id: number
      name: string
    }>
  }
  path: string
}

async function waitForRows(count: number) {
  let rows: Awaited<ReturnType<typeof queryBooks>> = []
  await eventually(async () => {
    rows = await queryBooks()
    return rows.length === count
  }, `expected ${count} replicated rows`)
  return rows
}

function queryBooks() {
  return zero.run(queries.contractBooks.all())
}

async function waitForCapturedMutation(id: string) {
  let match: CapturedRequest | undefined
  await eventually(async () => {
    const entries = await capturedRequests()
    match = entries.find(entry =>
      entry.body.mutations.some(mutation => {
        const args = mutation.args[0] as {id?: string} | undefined
        return mutation.name === 'contract_books.create' && args?.id === id
      }),
    )
    return match !== undefined
  }, `mutation ${id} was not captured`)
  return match!
}

async function capturedRequests(): Promise<CapturedRequest[]> {
  try {
    const contents = await readFile(mutationLogPath, 'utf8')
    return contents
      .split('\n')
      .filter(Boolean)
      .map(line => JSON.parse(line) as CapturedRequest)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return []
    }
    throw error
  }
}

async function eventually(
  predicate: () => Promise<boolean>,
  message: string,
  timeoutMs = 30_000,
) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await predicate()) {
      return
    }
    await delay(200)
  }
  throw new Error(message)
}

function requiredEnv(name: string) {
  const value = process.env[name]
  if (!value) {
    throw new Error(`${name} is required`)
  }
  return value
}
