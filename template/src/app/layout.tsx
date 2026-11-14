import './globals.css'; import type { ReactNode } from 'react'; import type { Viewport } from 'next';
export const metadata={title:'Design Sprites v3',description:'Verbatim record — waiting for a driver'};
// v3.5: declare both schemes as supported; the browser/OS preference alone
// decides which renders (globals.css prefers-color-scheme). No user setting.
export const viewport: Viewport={colorScheme:'light dark'};
export default function L({children}:{children:ReactNode}){return <html lang='en'><body>{children}</body></html>}
