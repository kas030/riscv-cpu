export type LabKind =
  | "architecture"
  | "pairing"
  | "forwarding"
  | "load"
  | "control"
  | "pipeline";

export interface SourceRef {
  id: string;
  label: string;
  path: string;
  symbol: string;
  why: string;
}

export interface GuidedExercise {
  question: string;
  hint: string;
  answer: string;
}

export interface LessonSection {
  id: string;
  title: string;
  lead?: string;
  paragraphs?: string[];
  bullets?: string[];
  code?: string;
  lab?: LabKind;
  sourceIds?: string[];
  exercise?: GuidedExercise;
}

export interface Lesson {
  slug: string;
  order: string;
  kicker: string;
  title: string;
  summary: string;
  objectives: string[];
  sections: LessonSection[];
}

export type PipelineStage = "IF" | "ID" | "EX" | "MEM1" | "MEM2" | "WB";
