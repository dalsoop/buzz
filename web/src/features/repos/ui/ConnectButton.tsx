import { ExternalLink } from "lucide-react";
import { useTranslation } from "react-i18next";

import { relayWsUrl } from "@/shared/lib/relay-url";
import { Button } from "@/shared/ui/button";

export function ConnectButton({ className }: { className?: string }) {
  const { t } = useTranslation();
  const deepLink = `buzz://connect?relay=${encodeURIComponent(relayWsUrl())}`;

  return (
    <Button
      asChild
      className={`bg-black text-white hover:bg-black/90 focus-visible:ring-black dark:bg-white dark:text-black dark:hover:bg-white/90 dark:focus-visible:ring-white ${className ?? ""}`}
    >
      <a href={deepLink}>
        <ExternalLink className="h-4 w-4" />
        {t("common.openInBuzz")}
      </a>
    </Button>
  );
}
