// tests/mirage-multipart.test.ts
//
// The hand-written multipart encoder in the Mirage client.
//
// It replaced `FormData` + `Blob` so that a 90 MiB GLB streams through this
// process instead of existing in it twice, and that trade is only worth making
// if the bytes it produces are actually a valid multipart body. A malformed one
// fails at multer — on Mirage, in production, after the whole upload — with an
// HTML error page nothing can classify. Hence this file.
//
// The two invariants:
//   • the body PARSES: correct boundaries, correct headers, correct payloads;
//   • `contentLength` equals the real byte count. It goes out as Content-Length,
//     and a wrong one truncates the request or hangs it.
import { describe, it, expect } from 'vitest';
import { Readable } from 'stream';

import { buildMultipart } from '@/services/mirage/mirageClient';
import { bytesUpload, type MirageStreamUpload } from '@/services/mirage';

async function collect(stream: Readable): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
}

const boundaryOf = (contentType: string): string =>
  contentType.slice(contentType.indexOf('boundary=') + 'boundary='.length);

/** A deliberately minimal multipart reader — enough to prove the shape. */
function parseParts(body: string, boundary: string): { headers: string; payload: string }[] {
  return body
    .split(`--${boundary}`)
    .slice(1, -1)
    .map((section) => {
      const trimmed = section.startsWith('\r\n') ? section.slice(2) : section;
      const split = trimmed.indexOf('\r\n\r\n');
      return {
        headers: trimmed.slice(0, split),
        // Every part payload is followed by the CRLF that precedes the boundary.
        payload: trimmed.slice(split + 4, -2),
      };
    });
}

function streamPart(size: number, chunks: number): MirageStreamUpload {
  return {
    kind: 'stream',
    filename: 'model.glb',
    contentType: 'model/gltf-binary',
    size,
    open: () =>
      Readable.from(
        (function* () {
          const each = Math.ceil(size / chunks);
          let sent = 0;
          while (sent < size) {
            const n = Math.min(each, size - sent);
            sent += n;
            yield Buffer.alloc(n, 0x41);
          }
        })()
      ),
  };
}

describe('buildMultipart', () => {
  it('encodes plain fields as multipart parts', async () => {
    const multipart = buildMultipart({}, { name: 'Chair', price: '1200' });
    const body = (await collect(multipart.stream)).toString('utf8');
    const parts = parseParts(body, boundaryOf(multipart.contentType));

    expect(parts).toHaveLength(2);
    expect(parts[0].headers).toContain('Content-Disposition: form-data; name="name"');
    expect(parts[0].payload).toBe('Chair');
    expect(parts[1].payload).toBe('1200');
  });

  it('encodes a bytes part with its filename and content type', async () => {
    const multipart = buildMultipart(
      { files: { image: bytesUpload('logo.png', 'image/png', Buffer.from('PNGDATA')) } },
      { name: 'Chair' }
    );
    const body = (await collect(multipart.stream)).toString('utf8');
    const parts = parseParts(body, boundaryOf(multipart.contentType));

    const file = parts[1];
    expect(file.headers).toContain('name="image"; filename="logo.png"');
    expect(file.headers).toContain('Content-Type: image/png');
    expect(file.payload).toBe('PNGDATA');
  });

  it('streams a stream part through without concatenating it', async () => {
    const multipart = buildMultipart(
      { files: { object: streamPart(10_000, 20) } },
      { name: 'Chair' }
    );
    const body = await collect(multipart.stream);
    const parts = parseParts(body.toString('latin1'), boundaryOf(multipart.contentType));

    expect(parts[1].payload).toHaveLength(10_000);
    expect(parts[1].headers).toContain('Content-Type: model/gltf-binary');
  });

  it('reports a contentLength equal to the bytes it actually emits', async () => {
    // THE ASSERTION THAT MATTERS. It is sent as Content-Length; if the arithmetic
    // and the generator ever disagree the request truncates or hangs, and the
    // symptom appears only against a real Mirage.
    const multipart = buildMultipart(
      {
        files: {
          image: bytesUpload('logo.png', 'image/png', Buffer.alloc(333, 1)),
          object: streamPart(7_777, 13),
        },
      },
      { name: 'Chair', CLOUD_FRONT_URL: 'https://cdn.test', BUCKET_NAME: 'bucket' }
    );

    const body = await collect(multipart.stream);

    expect(body.byteLength).toBe(multipart.contentLength);
  });

  it('closes the body with the terminating boundary', async () => {
    const multipart = buildMultipart({}, { name: 'Chair' });
    const body = (await collect(multipart.stream)).toString('utf8');
    const boundary = boundaryOf(multipart.contentType);

    expect(body.endsWith(`--${boundary}--\r\n`)).toBe(true);
  });

  it('uses a fresh boundary per request', () => {
    const a = buildMultipart({}, { name: 'A' });
    const b = buildMultipart({}, { name: 'B' });
    expect(boundaryOf(a.contentType)).not.toBe(boundaryOf(b.contentType));
  });
});
