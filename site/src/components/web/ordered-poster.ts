/**
 * Serializes frames over a request-per-frame transport (the HTTPS tunnel).
 *
 * Each POST starts only after the previous one has settled, so the relay sees
 * frames in send order. Concurrent POSTs can overtake each other, and the
 * relay closes a connection whose first frame after the challenge isn't
 * `auth`. The first failure is reported once; frames queued behind it are
 * dropped, because the connection is being torn down anyway.
 */
export function createOrderedPoster(
  post: (frame: string) => Promise<unknown>,
  onError: () => void,
): (frame: string) => void {
  let tail: Promise<unknown> = Promise.resolve();
  let failed = false;
  return (frame) => {
    tail = tail.then(async () => {
      if (failed) return;
      try {
        await post(frame);
      } catch {
        failed = true;
        onError();
      }
    });
  };
}
