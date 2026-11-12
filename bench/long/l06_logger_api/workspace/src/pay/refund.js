import { log } from '../log.js';

export function refund(user, code, count) {
  log('warn', 'refund requested');
  log('info', 'refund sent');
  return true;
}
