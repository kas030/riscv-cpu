import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { relative, resolve, sep } from "node:path";

async function collect(directory) {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) result.push(...await collect(path));
    else if (/\.(?:sv|v)$/.test(entry.name)) result.push(path);
  }
  return result;
}

export async function computeRtlDigest(repoRoot) {
  const files = (await collect(resolve(repoRoot, "rtl")))
    .map((absolutePath) => ({
      absolutePath,
      relativePath: relative(repoRoot, absolutePath).split(sep).join("/"),
    }))
    .filter(({ relativePath }) =>
      !relativePath.startsWith("rtl/peripheral/")
      && !relativePath.startsWith("rtl/soc/")
      && !relativePath.startsWith("rtl/top/"))
    .sort((left, right) => left.relativePath < right.relativePath ? -1 : left.relativePath > right.relativePath ? 1 : 0);
  const hash = createHash("sha256");
  for (const { absolutePath, relativePath } of files) {
    hash.update(relativePath);
    hash.update("\0");
    hash.update(await readFile(absolutePath));
    hash.update("\0");
  }
  return {
    rtlDigest: hash.digest("hex"),
    files: files.map(({ absolutePath }) => absolutePath),
  };
}
