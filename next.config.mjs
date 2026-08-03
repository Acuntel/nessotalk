/** @type {import('next').NextConfig} */
const nextConfig = {
  eslint: { ignoreDuringBuilds: true },
  // The installer zips are read at runtime by /api/download. They live outside
  // public/ so they are never served directly, which means the serverless
  // bundle has to be told to include them.
  outputFileTracingIncludes: {
    "/api/download": ["./assets/downloads/**"],
  },
};

export default nextConfig;
