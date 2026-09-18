namespace RunXcTiming.AppHost;

/// <summary>
/// Project-specific values used by AppHost.cs. Keep secrets out of source control in real
/// deployments (e.g. user secrets / environment variables); these defaults exist so the
/// project runs out of the box for local development.
/// </summary>
internal static class Constants
{
    /// <summary>Admin user seeded into Supabase auth and used for the Studio / Grafana login.</summary>
    public static class User
    {
        public static readonly (string Name, string Email, string Password) Default =
            ("admin", "admin@localhost", "admin");
    }
}
