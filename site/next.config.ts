import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // A plain static site in out/: no server, nothing to run but files.
  output: "export",
  images: { unoptimized: true },
};

export default nextConfig;
