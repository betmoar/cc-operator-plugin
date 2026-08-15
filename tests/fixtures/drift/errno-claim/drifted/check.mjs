// Precondition: the sentinel file must exist before we read its owner line.
// statSync throws ENOENT when the path is missing, which we treat as
// "no sentinel yet" and return null.
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
