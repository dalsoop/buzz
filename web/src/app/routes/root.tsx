import { Outlet, createRootRoute } from "@tanstack/react-router";

import { LanguageToggle } from "@/shared/i18n/LanguageToggle";

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  return (
    <div className="flex min-h-dvh flex-col">
      <LanguageToggle className="fixed top-2 right-2 z-40" />
      <main className="flex flex-1 flex-col">
        <Outlet />
      </main>
    </div>
  );
}
