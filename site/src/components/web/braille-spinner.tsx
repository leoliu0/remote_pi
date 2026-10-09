"use client";

import { useEffect, useState } from "react";

// Same frames and cadence as the phone's working banner (streaming_bubble.dart).
const BRAILLE_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

export function BrailleSpinner() {
  const [tick, setTick] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setTick((n) => n + 1), 80);
    return () => clearInterval(t);
  }, []);
  return <span aria-hidden className="w-3 inline-block">{BRAILLE_FRAMES[tick % BRAILLE_FRAMES.length]}</span>;
}
