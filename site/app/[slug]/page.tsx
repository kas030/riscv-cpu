import { notFound } from "next/navigation";
import { CourseShell } from "../CourseShell";
import { lessonSlugs } from "../content";

export function generateStaticParams() {
  return lessonSlugs.filter((slug) => slug !== "home").map((slug) => ({ slug }));
}

export default async function LessonPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  if (!lessonSlugs.includes(slug)) notFound();
  return <CourseShell slug={slug} />;
}
