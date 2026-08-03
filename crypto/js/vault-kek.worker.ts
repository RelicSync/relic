// Web worker that runs the Argon2id derivation off the main thread, so the
// 64 MiB / ~3 s unlock doesn't freeze the tab. Spawned by deriveKekOffThread
// in vault-crypto.ts; receives {passphrase, salt, params}, posts back the KEK.

import { argon2id } from "hash-wasm";

self.onmessage = async (e: MessageEvent) => {
  const { passphrase, salt, params } = e.data as {
    passphrase: string;
    salt: Uint8Array;
    params: { m_kib: number; t: number; p: number };
  };
  try {
    const kek = await argon2id({
      password: new TextEncoder().encode(passphrase),
      salt,
      iterations: params.t,
      parallelism: params.p,
      memorySize: params.m_kib,
      hashLength: 32,
      outputType: "binary",
    });
    self.postMessage({ ok: true, kek }, { transfer: [kek.buffer as ArrayBuffer] });
  } catch (err) {
    self.postMessage({ ok: false, error: String(err) });
  }
};
