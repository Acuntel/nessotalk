import Link from "next/link";

export default function Nav() {
  return (
    <header className="fixed inset-x-0 top-0 z-50 border-b border-edge bg-ink/80 backdrop-blur">
      <nav className="mx-auto flex h-16 max-w-6xl items-center justify-between px-5">
        <Link href="/" className="flex items-center gap-2">
          <span className="flex h-7 items-end gap-[2.5px]">
            {[10, 22, 14, 26, 12].map((h, i) => (
              <span
                key={i}
                className="w-[3px] rounded-full bg-volt"
                style={{ height: `${h}px` }}
              />
            ))}
          </span>
          <span className="font-display text-xl font-semibold tracking-tight">
            NessoTalk
          </span>
        </Link>
        <div className="hidden items-center gap-8 text-sm text-mist sm:flex">
          <a href="/#how" className="hover:text-cream">How it works</a>
          <a href="/#pricing" className="hover:text-cream">Pricing</a>
          <a href="/#faq" className="hover:text-cream">FAQ</a>
        </div>
        <div className="flex items-center gap-3">
          <Link href="/start?mode=signin" className="text-sm text-mist hover:text-cream">
            Sign in
          </Link>
          <Link
            href="/start"
            className="rounded-lg bg-volt px-4 py-2 text-sm font-semibold text-white transition hover:bg-voltdim"
          >
            Start free trial
          </Link>
        </div>
      </nav>
    </header>
  );
}
