// src/utils/glb.ts
//
// Binary-glTF header sniffing, for the staff "Submit model" flow.
//
// WHY THE BYTES DECIDE. The submit path signs a presigned PUT with a declared
// Content-Type, and the client only offers `.glb` in its file picker — but
// neither is evidence: the header is caller-supplied and an extension is a
// naming convention. The one thing that cannot be faked into working is the
// file's own magic, and the cost of trusting the label is an owner opening a
// project to a model their phone refuses to load.
//
// Same stance, and the same reason, as `sniffImageContentType` on the avatar
// path: the declared type is never trusted.

/** Bytes a caller must read off the front of a file for {@link isGlbHeader}. */
export const GLB_HEADER_BYTES = 12;

/** `glTF` — the 4-byte magic that opens every binary glTF file. */
const GLB_MAGIC = 0x46546c67;

/**
 * The only container version this pipeline accepts. glTF 1.0 binary is a
 * different, incompatible layout that neither three.js nor <model-viewer>
 * loads — accepting it would store a file no client can open.
 */
const GLB_VERSION = 2;

/**
 * Whether [header] opens a glTF 2.0 binary file.
 *
 * Checks the 12-byte header exactly as the spec defines it: magic, version, and
 * a total-length field. [totalBytes], when known, is compared against that
 * length field — a GLB whose header disagrees with the object's real size is
 * truncated or spliced, and it is cheaper to refuse it here than to let the
 * owner discover it.
 */
export function isGlbHeader(header: Buffer, totalBytes?: number): boolean {
  if (header.length < GLB_HEADER_BYTES) return false;
  if (header.readUInt32LE(0) !== GLB_MAGIC) return false;
  if (header.readUInt32LE(4) !== GLB_VERSION) return false;
  const declaredLength = header.readUInt32LE(8);
  if (declaredLength < GLB_HEADER_BYTES) return false;
  return totalBytes === undefined || declaredLength === totalBytes;
}
