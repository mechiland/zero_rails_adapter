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

  const firstID = crypto.randomUUID()
  const first = await zero.mutate(
    mutators.contract_books.create({
      id: firstID,
      sync_id: 'sync-book-1',
      title: 'First',
    }),
  ).server
  assert.equal(first.type, 'success')
  await waitForRows(1)

  const captured = await waitForCapturedMutation(firstID)
  const invalidKeyResponse = await fetch(
    `${railsMutateURL}${captured.path}`,
    {
      body: JSON.stringify(captured.body),
      headers: {
        'content-type': 'application/json',
        'x-api-key': 'invalid',
      },
      method: 'POST',
    },
  )
  assert.equal(invalidKeyResponse.status, 401)
  assert.equal(
    (await invalidKeyResponse.json() as {kind: string}).kind,
    'Unauthorized',
  )

  const invalidTokenResponse = await fetch(
    `${railsMutateURL}${captured.path}`,
    {
      body: JSON.stringify(captured.body),
      headers: {
        authorization: 'Bearer invalid',
        'content-type': 'application/json',
        'x-api-key': apiKey,
      },
      method: 'POST',
    },
  )
  assert.equal(invalidTokenResponse.status, 401)
  assert.equal(
    (await invalidTokenResponse.json() as {kind: string}).kind,
    'Unauthorized',
  )

  const missingAuthorization = await postDirectMutation(
    captured,
    directMutationBody(
      captured,
      'missing-authorization-client',
      'contract.missing_authorization',
    ),
  )
  assert.equal(missingAuthorization.kind, 'MutateResponse')
  assert.equal(
    missingAuthorization.mutations?.[0]?.result.error,
    'app',
  )
  assert.equal(
    missingAuthorization.mutations?.[0]?.result.message,
    'Mutator authorization is not configured',
  )

  const denied = await postDirectMutation(
    captured,
    directMutationBody(captured, 'denied-client', 'contract.retry'),
    {'x-contract-deny': 'true'},
  )
  assert.equal(denied.kind, 'MutateResponse')
  assert.equal(denied.mutations?.[0]?.result.error, 'app')
  assert.equal(
    denied.mutations?.[0]?.result.message,
    'Mutation is not authorized',
  )

  const retryClientID = 'retry-safe-client'
  const retryBody = directMutationBody(
    captured,
    retryClientID,
    'contract.retry',
  )
  const retrySafeFailure = await postDirectMutation(
    captured,
    retryBody,
    {'x-contract-fail': 'true'},
  )
  assert.equal(retrySafeFailure.kind, 'PushFailed')
  assert.equal(retrySafeFailure.reason, 'internal')
  assert.equal(retrySafeFailure.message, 'Internal server error')
  assert.doesNotMatch(
    JSON.stringify(retrySafeFailure),
    /private contract implementation detail/,
  )
  const failedLMID = await database.query<{count: string}>(
    'SELECT count(*) FROM "contract_0"."clients" WHERE "clientID" = $1',
    [retryClientID],
  )
  assert.equal(Number(failedLMID.rows[0]?.count), 0)

  const retried = await postDirectMutation(captured, retryBody)
  assert.equal(retried.kind, 'MutateResponse')
  assert.deepEqual(
    retried.mutations?.[0]?.result.data,
    {replayed: true},
  )
  const retriedLMID = await database.query<{lastMutationID: string}>(
    'SELECT "lastMutationID" FROM "contract_0"."clients" WHERE "clientID" = $1',
    [retryClientID],
  )
  assert.equal(Number(retriedLMID.rows[0]?.lastMutationID), 1)

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

  const invalidID = crypto.randomUUID()
  const failed = await zero.mutate(
    mutators.contract_books.create({
      id: invalidID,
      sync_id: 'sync-book-invalid',
      title: '',
    }),
  ).server
  assert.equal(failed.type, 'error')
  if (failed.type === 'error') {
    assert.equal(failed.error.type, 'app')
  }

  const secondID = crypto.randomUUID()
  const third = await zero.mutate(
    mutators.contract_books.create({
      id: secondID,
      sync_id: 'sync-book-2',
      title: 'After failure',
    }),
  ).server
  assert.equal(third.type, 'success')

  const rows = await waitForRows(2)
  assert.deepEqual(
    Object.fromEntries(rows.map(row => [
      row.sync_id,
      [row.id, row.title, row.labels.map(label => label.name)],
    ])),
    {
      'sync-book-1': [firstID, 'First', ['Label First']],
      'sync-book-2': [secondID, 'After failure', ['Label After failure']],
    },
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
    book_id_type: string
    labels: string
    links: string
  }>(
    'SELECT ' +
      '(SELECT count(*) FROM contract_labels) AS labels, ' +
      '(SELECT count(*) FROM contract_book_labels) AS links, ' +
      'pg_typeof((SELECT book_id FROM contract_book_labels LIMIT 1))::text ' +
      'AS book_id_type',
  )
  assert.equal(Number(relatedCounts.rows[0]?.labels), 2)
  assert.equal(Number(relatedCounts.rows[0]?.links), 2)
  assert.equal(relatedCounts.rows[0]?.book_id_type, 'uuid')
  console.log(
    'Zero 1.8 UUID schema, Zero key, relationship, authentication, ' +
      'authorization, mutation, replication, query, LMID, retry, ' +
      'and cleanup contract passed',
  )
} finally {
  await zero.close()
  await database.end()
}

type CapturedRequest = {
  body: {
    clientGroupID: string
    mutations: Array<{
      args: unknown[]
      clientID: string
      id: number
      name: string
      timestamp: number
    }>
    pushVersion: number
    requestID: string
    timestamp: number
  }
  path: string
}

type DirectMutationResponse = {
  kind: string
  message?: string
  mutations?: Array<{
    result: {
      data?: unknown
      error?: string
      message?: string
    }
  }>
  reason?: string
}

function directMutationBody(
  captured: CapturedRequest,
  clientID: string,
  name: string,
) {
  const original = captured.body.mutations[0]
  assert.ok(original)
  return {
    ...captured.body,
    requestID: crypto.randomUUID(),
    mutations: [{
      ...original,
      args: [{}],
      clientID,
      id: 1,
      name,
    }],
  }
}

async function postDirectMutation(
  captured: CapturedRequest,
  body: CapturedRequest['body'],
  headers: Record<string, string> = {},
) {
  const response = await fetch(`${railsMutateURL}${captured.path}`, {
    body: JSON.stringify(body),
    headers: {
      'content-type': 'application/json',
      'x-api-key': apiKey,
      ...headers,
    },
    method: 'POST',
  })
  assert.equal(response.status, 200)
  return response.json() as Promise<DirectMutationResponse>
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
