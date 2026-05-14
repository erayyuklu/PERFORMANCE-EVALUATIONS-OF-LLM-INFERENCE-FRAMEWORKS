"""
GAIA exact-match scorer.
========================
Normalizes both predicted and expected answers, then checks equality.
GAIA answers are designed to be short and unambiguous — exact match
after normalization is the official scoring protocol.
"""

import re
import unicodedata

# LaTeX commands to strip (map to plain-text equivalents)
_LATEX_MAP = [
    (r"\leftrightarrow", "↔"), (r"\rightarrow", "→"), (r"\to", "→"),
    (r"\neg", "¬"), (r"\lor", "∨"), (r"\vee", "∨"),
    (r"\land", "∧"), (r"\wedge", "∧"),
]

# Unit suffixes that may be appended to numeric answers
_UNIT_SUFFIXES = re.compile(
    r"(?<=\d)\s*"
    r"(m[²³23]?|m\^[23]|km[²³23]?|cm[²³23]?|mm[²³23]?|kg|g|lb|lbs|ft[²³23]?|in|mi|mph|km/h|kwh"
    r"|°[cfk]|degrees?|hrs?|hours?|min|minutes?|sec|seconds?|days?|years?"
    r"|usd|eur|gbp|dollars?|euros?|pounds?)$",
    re.IGNORECASE,
)


def _normalize(text: str) -> str:
    """Normalize an answer string for comparison."""
    # Unicode → ASCII-friendly form
    text = unicodedata.normalize("NFKD", text)
    # Strip LaTeX math-mode delimiters: $...$
    text = re.sub(r"^\$+|\$+$", "", text)
    # Replace LaTeX commands with Unicode equivalents
    for latex, replacement in _LATEX_MAP:
        text = text.replace(latex, replacement)
    # Lowercase
    text = text.lower().strip()
    # Strip trailing period (common in full-sentence answers)
    text = re.sub(r"\.$", "", text)
    # Strip common currency / unit decorators
    text = re.sub(r"^[\$€£¥]", "", text)
    text = re.sub(r"%$", "", text)
    # Remove commas in numbers (e.g. "1,000" → "1000")
    text = re.sub(r"(?<=\d),(?=\d)", "", text)
    # Strip trailing ".0" for integers expressed as floats
    text = re.sub(r"\.0+$", "", text)
    # Strip unit suffixes after numbers (e.g. "0.1777 m3" → "0.1777")
    text = _UNIT_SUFFIXES.sub("", text)
    # Strip spaces adjacent to logical/math symbols (¬A vs ¬ A)
    text = re.sub(r"([¬∨∧→↔])\s+", r"\1", text)
    text = re.sub(r"\s+([¬∨∧→↔])", r" \1", text)
    # Normalize list separators: "a, b, c" and "a,b,c" → "a, b, c"
    text = re.sub(r"\s*,\s*", ", ", text)
    # Collapse internal whitespace
    text = re.sub(r"\s+", " ", text).strip()
    return text


def score(predicted: str, expected: str) -> int:
    """Return 1 if predicted matches expected after normalization, else 0."""
    return int(_normalize(predicted) == _normalize(expected))