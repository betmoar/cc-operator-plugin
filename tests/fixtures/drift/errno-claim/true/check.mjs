// Precondition: the sentinel file must exist before we read its owner line.
// statSync can throw for many reasons (ENOENT, EACCES, a symlink loop); we
// treat ANY throw here as "no sentinel yet" and return null rather than
// distinguishing the cause.
export function ownerOrNull(statSync, path) {
  try {
    statSync(path);
  } catch (e) {
    // any throw here means "no sentinel" — not just ENOENT
    return null;
  }
  return readOwnerLine(path);
}

function readOwnerLine(path) {
  return `owner-of-${path}`;
}
