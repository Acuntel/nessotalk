// One definition of "is this person allowed to use NessoTalk right now".
//
// This existed in four places that had already drifted apart: /api/download let
// a live trial through while /api/update rejected every trial outright, so a
// customer inside their fourteen free days could install the app and then never
// receive an update. Anything that gates access imports from here.
//
// The rule is an ALLOWLIST on purpose. The old checks asked "is the plan trial?",
// which quietly treats any unexpected string as paid.

export type AccessRow = {
  plan?: string | null;
  trial_ends_at?: string | null;
  revoked?: boolean | null;
};

export type AccessVerdict =
  | { ok: true; reason: "pro" | "trial" }
  | { ok: false; reason: "unknown" | "revoked" | "expired" | "no_plan" };

export function accessFor(row: AccessRow | null | undefined): AccessVerdict {
  if (!row) return { ok: false, reason: "unknown" };
  if (row.revoked) return { ok: false, reason: "revoked" };

  if (row.plan === "pro") return { ok: true, reason: "pro" };

  if (row.plan === "trial") {
    // A null trial_ends_at is treated as expired rather than infinite. An
    // access check should fail closed when the data it needs is missing.
    const ends = row.trial_ends_at ? Date.parse(row.trial_ends_at) : NaN;
    if (Number.isNaN(ends)) return { ok: false, reason: "expired" };
    return ends > Date.now()
      ? { ok: true, reason: "trial" }
      : { ok: false, reason: "expired" };
  }

  return { ok: false, reason: "no_plan" };
}

// HTTP status that matches the verdict: 402 means "pay or renew", which is what
// every one of these failures actually is.
export function accessStatus(v: AccessVerdict): number {
  return v.ok ? 200 : 402;
}
