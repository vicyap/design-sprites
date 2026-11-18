import type { NextConfig } from 'next';
const c: NextConfig = {
  output: 'standalone',
  // v4 F2: the Agentation toolbar syncs through a same-origin path; the
  // agentation-mcp server itself stays on loopback (never publicly exposed).
  async rewrites() {
    return [{ source: '/agentation-sync/:path*', destination: 'http://127.0.0.1:4747/:path*' }];
  },
};
export default c;
