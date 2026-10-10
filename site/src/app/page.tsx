import { CircleAnything } from "@/components/site/circle-anything";
import { Coders } from "@/components/site/coders";
import { Colours } from "@/components/site/colours";
import { CursorBuddy } from "@/components/site/cursor-buddy";
import { Faq } from "@/components/site/faq";
import { Footer } from "@/components/site/footer";
import { Hero } from "@/components/site/hero";
import { HowToAsk } from "@/components/site/how-to-ask";
import { MacActions } from "@/components/site/mac-actions";
import { MenuBar } from "@/components/site/menu-bar";
import { Private } from "@/components/site/private";
import { Setup } from "@/components/site/setup";
import { Story } from "@/components/site/story";
import { Walkthroughs } from "@/components/site/walkthroughs";

export default function Home() {
  return (
    <>
      <a
        href="#main"
        className="sr-only z-[80] rounded-lg bg-white px-4 py-2 font-semibold text-black focus:not-sr-only focus:fixed focus:left-4 focus:top-3"
      >
        Skip to content
      </a>
      <MenuBar />
      <main id="main">
        <Hero />
        <Colours />
        <HowToAsk />
        <Walkthroughs />
        <CircleAnything />
        <Coders />
        <MacActions />
        <Private />
        <Story />
        <Setup />
        <Faq />
      </main>
      <Footer />
      <CursorBuddy />
    </>
  );
}
