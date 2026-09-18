import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import {
  AUTHOR,
  DESCRIPTION,
  IS_PREVIEW,
  KEYWORDS,
  OG_ALT,
  OG_IMAGE,
  SITE_NAME,
  SITE_URL,
  TITLE,
  structuredData,
} from "@/lib/seo";
import "./globals.css";

const geistSans = Geist({
  subsets: ["latin"],
  variable: "--font-geist-sans",
  display: "swap",
});

const geistMono = Geist_Mono({
  subsets: ["latin"],
  variable: "--font-geist-mono",
  display: "swap",
});

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: TITLE,
    template: `%s | ${SITE_NAME}`,
  },
  description: DESCRIPTION,
  applicationName: SITE_NAME,
  keywords: KEYWORDS,
  authors: [{ name: AUTHOR.name, url: AUTHOR.url }],
  creator: AUTHOR.name,
  publisher: AUTHOR.name,
  category: "Utilities",
  alternates: { canonical: "/" },
  openGraph: {
    type: "website",
    url: `${SITE_URL}/`,
    siteName: SITE_NAME,
    title: TITLE,
    description: DESCRIPTION,
    locale: "en_US",
    images: [{ ...OG_IMAGE, alt: OG_ALT }],
  },
  twitter: {
    card: "summary_large_image",
    title: TITLE,
    description: DESCRIPTION,
    images: [{ url: OG_IMAGE.url, alt: OG_ALT }],
  },
  robots: {
    index: !IS_PREVIEW,
    follow: true,
    googleBot: {
      index: !IS_PREVIEW,
      follow: true,
      "max-image-preview": "large",
      "max-snippet": -1,
      "max-video-preview": -1,
    },
  },
};

export const viewport: Viewport = {
  colorScheme: "dark",
  // Next needs a literal here, so this mirrors --color-ink-950 in globals.css.
  themeColor: "#08090a",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable}`}>
      <body className="grain antialiased">
        {/*
          One @graph describing the site, the page, the author, the app itself and the
          FAQ. The app entry is what encodes "free and open source" for machines:
          isAccessibleForFree plus a 0 USD offer, and the MIT licence URL.
        */}
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(structuredData) }}
        />
        <a
          href="#top"
          className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-50 focus:rounded-full focus:bg-aqua-500 focus:px-4 focus:py-2 focus:text-[13px] focus:font-medium focus:text-ink-1000"
        >
          Skip to content
        </a>
        {children}
      </body>
    </html>
  );
}