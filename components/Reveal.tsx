"use client";

import { motion, type Variants } from "framer-motion";
import type { ReactNode } from "react";

// Same reveal rhythm as the Simply Scaled site: things ease up into place as
// they enter view, once, at a pace that reads comfortably while scrolling.
const variants: Variants = {
  hidden: { opacity: 0, y: 26 },
  show: (i: number) => ({
    opacity: 1,
    y: 0,
    transition: { duration: 0.65, ease: [0.22, 1, 0.36, 1], delay: i * 0.09 },
  }),
};

export function Reveal({
  children,
  delay = 0,
  className,
}: {
  children: ReactNode;
  delay?: number;
  className?: string;
}) {
  return (
    <motion.div
      className={className}
      variants={variants}
      custom={delay}
      initial="hidden"
      whileInView="show"
      viewport={{ once: true, margin: "-90px" }}
    >
      {children}
    </motion.div>
  );
}
