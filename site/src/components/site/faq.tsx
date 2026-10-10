import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/animated-accordion";
import { MODEL, MODEL_SIZE } from "@/lib/site";
import { BaitHeading, Section } from "./bits";

const FAQS: { q: string; a: React.ReactNode }[] = [
  {
    q: "Why does it need the microphone, Screen Recording and Accessibility?",
    a: (
      <ul className="list-disc space-y-1.5 pl-5">
        <li>
          <strong className="text-white">Microphone:</strong> to hear your question while you hold ⌃⌥. Not before, not after.
        </li>
        <li>
          <strong className="text-white">Screen Recording:</strong> to see the screen you’re asking about. Screenshots stay in memory and
          aren’t kept.
        </li>
        <li>
          <strong className="text-white">Accessibility:</strong> to notice its shortcuts in any app, and to aim at real buttons rather
          than guessing.
        </li>
      </ul>
    ),
  },
  {
    q: "How big are the downloads?",
    a: `The AI model (${MODEL}) is about ${MODEL_SIZE}, downloaded once through Ollama. The speech model is about 145 MB (there’s a 75 MB one for speed and a 480 MB one for accuracy). Keep around 10 GB free and you’re comfortable.`,
  },
  {
    q: "Does it really work offline?",
    a: "Yes, once the two models are downloaded. Questions, explanations, walkthroughs and Mac actions all run on your Mac. Opening a website still needs the internet, obviously. There’s one optional extra, off every time ClickBait starts: switch on “Look Up Snips on Wikipedia” in the menu and, when you circle a picture, the name of what it shows (just that, never your screen or anyone’s name) is looked up on Wikipedia to label its parts better.",
  },
  {
    q: "How fast is it?",
    a: "Honestly: it depends what you ask. Pointing at a button it can name is near-instant. Anything where it has to look at your screen and think takes several seconds, because it’s running on your Mac rather than a warehouse of servers.",
  },
  {
    q: "Does it ever click things for me?",
    a: "Walkthroughs only point: you do the clicking. Mac actions (opening apps, moving files, making notes) do things when you ask, and if it had to work out what you meant, anything risky asks first.",
  },
  {
    q: "Which languages does it understand?",
    a: "English, for now: the speech models it uses are the English-only ones, because they’re faster and more accurate.",
  },
  {
    q: "How do I uninstall it?",
    a: (
      <ol className="list-decimal space-y-1.5 pl-5">
        <li>Quit ClickBait from its menu bar icon, then drag it from Applications to the Trash.</li>
        <li>
          Free the model’s space: <code className="rounded bg-white/10 px-1.5 py-0.5 font-mono text-sm text-white">ollama rm {MODEL}</code>
        </li>
        <li>
          Delete the speech model in <code className="rounded bg-white/10 px-1.5 py-0.5 font-mono text-sm text-white">~/Library/Application Support/ClickBait</code>
        </li>
        <li>Remove it from System Settings → Privacy &amp; Security (Microphone, Screen Recording, Accessibility).</li>
      </ol>
    ),
  },
];

export function Faq() {
  return (
    <Section id="faq" tone="pumpkin" labelledBy="faq-title">
      <div className="grid gap-12 lg:grid-cols-[2fr_3fr]">
        <BaitHeading id="faq-title" tone="pumpkin" kicker="FAQ" bait="7 questions you’re too embarrassed to ask">
          Questions, answered.
        </BaitHeading>
        <Accordion type="single" collapsible className="w-full">
          {FAQS.map(({ q, a }) => (
            <AccordionItem key={q} value={q} className="border-white/[0.08]">
              <AccordionTrigger className="py-5 text-base font-semibold hover:no-underline sm:text-lg">{q}</AccordionTrigger>
              <AccordionContent className="pb-5 text-base leading-relaxed text-muted-foreground">{a}</AccordionContent>
            </AccordionItem>
          ))}
        </Accordion>
      </div>
    </Section>
  );
}
