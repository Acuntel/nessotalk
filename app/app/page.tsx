import { redirect } from "next/navigation";
import { supabaseServer } from "@/lib/supabase/server";
import Dashboard from "@/components/Dashboard";

export const dynamic = "force-dynamic";

export default async function AppPage() {
  const supabase = supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/start");

  const { data: profile } = await supabase
    .from("profiles")
    .select("email, plan, trial_ends_at, created_at, license_key")
    .eq("id", user.id)
    .single();

  const trialEnds = profile?.trial_ends_at ? new Date(profile.trial_ends_at) : null;
  const daysLeft = trialEnds
    ? Math.max(0, Math.ceil((trialEnds.getTime() - Date.now()) / 86_400_000))
    : 0;

  return (
    <Dashboard
      email={profile?.email ?? user.email ?? ""}
      uid={user.id}
      plan={profile?.plan ?? "trial"}
      daysLeft={daysLeft}
    />
  );
}
