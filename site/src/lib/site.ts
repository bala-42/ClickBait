// Everything a release changes lives here.

/** PLACEHOLDER: the friends-beta download (.dmg or .zip). Until it's real, the button goes to setup. */
export const DOWNLOAD_URL = "#setup";
export const DOWNLOAD_IS_PLACEHOLDER = true;

/** PLACEHOLDER: the public GitHub repo. Until it's public, links go to the open-source section. */
export const GITHUB_URL = "#open";
export const GITHUB_IS_PLACEHOLDER = true;

export const MODEL = "qwen3.5:9b";
export const MODEL_SIZE = "6.6 GB";

/** The five states, from ClickBait/Overlay/OverlayModel.swift (CompanionTone). */
export const TONES = {
  azure: { hex: "#007FFF", text: "#5CADFF", name: "Azure" },
  pumpkin: { hex: "#FF7518", text: "#FF9A52", name: "Pumpkin" },
  shamrock: { hex: "#009E61", text: "#3FD59A", name: "Shamrock" },
  strawberry: { hex: "#FA385C", text: "#FF7590", name: "Strawberry" },
  lavender: { hex: "#B57EDC", text: "#CFA6EC", name: "Lavender" },
} as const;

export type Tone = keyof typeof TONES;
