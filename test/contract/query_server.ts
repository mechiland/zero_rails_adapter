import {createServer} from 'node:http'
import {handleQueryRequest} from '@rocicorp/zero/server'
import {mustGetQuery} from '@rocicorp/zero'
import {queries} from './queries.js'
import {schema} from './generated/schema.js'

const port = Number.parseInt(process.env.QUERY_PORT ?? '', 10)
if (!Number.isInteger(port)) {
  throw new Error('QUERY_PORT is required')
}

const server = createServer(async (incoming, response) => {
  const requestURL = new URL(
    incoming.url ?? '/',
    `http://127.0.0.1:${port}`,
  )
  if (incoming.method === 'GET' && requestURL.pathname === '/health') {
    response.writeHead(200).end('ok')
    return
  }
  if (incoming.method !== 'POST' || requestURL.pathname !== '/query') {
    response.writeHead(404).end()
    return
  }

  try {
    const chunks: Buffer[] = []
    for await (const chunk of incoming) {
      chunks.push(Buffer.from(chunk))
    }
    const request = new Request(requestURL, {
      method: 'POST',
      headers: incoming.headers as HeadersInit,
      body: Buffer.concat(chunks),
    })
    const result = await handleQueryRequest({
      handler: (name, args) => {
        const query = mustGetQuery(queries, name)
        return query.fn({args})
      },
      request,
      schema,
      userID: null,
    })

    response.writeHead(200, {'content-type': 'application/json'})
    response.end(JSON.stringify(result))
  } catch (error) {
    console.error(error)
    response.writeHead(500, {'content-type': 'application/json'})
    response.end(JSON.stringify({error: String(error)}))
  }
})

server.listen(port, '127.0.0.1')

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => server.close())
}
