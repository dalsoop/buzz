import i18n from "i18next";
import { initReactI18next } from "react-i18next";

import en from "./locales/en.json";
import ko from "./locales/ko.json";

export const LANGUAGES = ["en", "ko"] as const;
export type Language = (typeof LANGUAGES)[number];

const STORAGE_KEY = "buzz.web.language";

function isLanguage(value: unknown): value is Language {
  return LANGUAGES.includes(value as Language);
}

/** `?lang=` wins, then a saved choice, then the browser's preferred language. */
function detectLanguage(): Language {
  const fromQuery = new URLSearchParams(window.location.search).get("lang");
  if (isLanguage(fromQuery)) return fromQuery;
  try {
    const saved = window.localStorage.getItem(STORAGE_KEY);
    if (isLanguage(saved)) return saved;
  } catch {
    // Storage can be unavailable (private mode, blocked site data).
  }
  for (const tag of navigator.languages ?? [navigator.language]) {
    const base = tag?.toLowerCase().split("-")[0];
    if (isLanguage(base)) return base;
  }
  return "en";
}

i18n.on("languageChanged", (language) => {
  document.documentElement.lang = language;
});

void i18n.use(initReactI18next).init({
  resources: {
    en: { translation: en },
    ko: { translation: ko },
  },
  lng: detectLanguage(),
  fallbackLng: "en",
  supportedLngs: LANGUAGES,
  initAsync: false,
  interpolation: {
    // React already escapes rendered strings.
    escapeValue: false,
  },
});

export function setLanguage(language: Language) {
  try {
    window.localStorage.setItem(STORAGE_KEY, language);
  } catch {
    // The choice still applies for this session.
  }
  void i18n.changeLanguage(language);
}

export { i18n };
