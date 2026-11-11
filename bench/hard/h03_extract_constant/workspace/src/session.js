const LIMIT = 24 * 3600;

export function isExpired(ageSeconds) {
  return ageSeconds > LIMIT;
}
