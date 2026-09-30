// Edge Function의 'npm:패키지@버전' import를 로컬 tests/e2e/node_modules로 연결 (시험 전용)
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const PARENT = pathToFileURL(path.join(HERE, 'resolver.mjs')).href;
export async function resolve(specifier, context, next) {
  if (specifier.startsWith('npm:')) {
    const bare = specifier.slice(4);
    const name = bare.startsWith('@') ? '@' + bare.slice(1).split('@')[0] : bare.split('@')[0];
    return next(name, { ...context, parentURL: PARENT });
  }
  if (specifier.startsWith('@supabase/') && context.parentURL && !context.parentURL.includes('/node_modules/')) {
    return next(specifier, { ...context, parentURL: PARENT });
  }
  return next(specifier, context);
}
