import type { Metadata } from "next";
import { SiteFooter, SiteHeader } from "./components";
import "./globals.css";

export const metadata: Metadata = {
  title: {
    default: "x86-64 OS Field Notes",
    template: "%s · x86-64 OS Field Notes",
  },
  description: "从 CPU 复位开始，以实验和证据构建自己的 x86-64 操作系统。",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="zh-CN">
      <body>
        <SiteHeader />
        {children}
        <SiteFooter />
      </body>
    </html>
  );
}
