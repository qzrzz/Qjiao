import { useEffect, useRef, useState } from "react";
import { getCurrentLang, getLangUrl, type SupportedLang } from "../i18n/dict";
import "./LanguageSwitcher.css";

const languages: { code: SupportedLang; label: string }[] = [
  { code: "en", label: "English" },
  { code: "zh-Hans", label: "简体中文" },
  { code: "ja", label: "日本語" },
];

interface LanguageSwitcherProps {
  currentLang?: SupportedLang;
}

/** 下拉菜单风格的多语言切换组件 */
export function LanguageSwitcher({ currentLang }: LanguageSwitcherProps) {
  const [isOpen, setIsOpen] = useState(false);
  const activeLang = currentLang || getCurrentLang();
  const dropdownRef = useRef<HTMLDivElement>(null);

  const currentObj = languages.find((l) => l.code === activeLang) || languages[0];

  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
    };
  }, []);

  return (
    <div className="langDropdown" ref={dropdownRef}>
      <button
        type="button"
        className={`langDropdownTrigger ${isOpen ? "langDropdownTrigger--open" : ""}`}
        onClick={() => setIsOpen(!isOpen)}
        aria-expanded={isOpen}
        aria-label="Select Language"
      >
        <GlobeIcon />
        <span>{currentObj.label}</span>
        <ChevronIcon className={`langChevron ${isOpen ? "langChevron--open" : ""}`} />
      </button>

      {isOpen && (
        <div className="langDropdownMenu" role="menu">
          {languages.map((lang) => {
            const isActive = lang.code === activeLang;
            const targetUrl = getLangUrl(lang.code, activeLang);

            return (
              <a
                key={lang.code}
                className={`langDropdownItem ${isActive ? "langDropdownItem--active" : ""}`}
                href={targetUrl}
                hrefLang={lang.code}
                role="menuitem"
                onClick={() => setIsOpen(false)}
              >
                <span>{lang.label}</span>
                {isActive && <CheckIcon />}
              </a>
            );
          })}
        </div>
      )}
    </div>
  );
}

function GlobeIcon() {
  return (
    <svg className="langIcon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="10" />
      <line x1="2" y1="12" x2="22" y2="12" />
      <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10z" />
    </svg>
  );
}

function ChevronIcon({ className }: { className?: string }) {
  return (
    <svg className={className || "langChevron"} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="6 9 12 15 18 9" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg className="langCheck" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="20 6 9 17 4 12" />
    </svg>
  );
}
