# Remote Pi — Site (Next.js)

Official website for Remote Pi. Presents project, GitHub links, and documentation.

## Stack

- Next.js 16 (App Router)
- React 19
- TypeScript 5
- Tailwind 4 (via `@tailwindcss/postcss`)
- ESLint 9
- Package manager: **pnpm**

## Commands

- `pnpm install` — install dependencies
- `pnpm dev` — dev server on :3000
- `pnpm build` — production build
- `pnpm start` — serve production build
- `pnpm lint` — ESLint
- `pnpm test` — tests

## Conventions

- **Server Components by default** — only use `"use client"` when necessary (state, events, hooks)
- **Routes folder**: `src/app/` (App Router)
- **Styles**: Tailwind utility-first. No CSS modules / styled-components
- **Images**: `next/image` with static fallback where applicable
- **Typing**: strictly typed component props without `any`

## Deployment

The site runs in production as a Docker image on Docker Hub: `jacobmoura7/remote-pi-site`.

```bash
./push-docker.sh            # multi-platform build + push, tag :latest
./push-docker.sh v1.2.3     # tag :v1.2.3 AND :latest
```
