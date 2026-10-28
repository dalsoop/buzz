import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";
import "./i18n";

const root = document.getElementById("root");
if (!root) throw new Error("root element missing");
createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
