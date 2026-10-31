// O corvo animado num canvas (pixel art, sem suavizar), com a mesma arte do ícone da área de notificação.
import { useEffect, useRef } from "react";
import art from "../../../shared/pet-art.json";

type Art = { width: number; height: number; palette: Record<string, string>; moods: Record<string, { fps: number; frames: string[][] }> };
const ART = art as Art;

export function PetSprite({ mood, scale = 4 }: { mood: string; scale?: number }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const animation = ART.moods[mood] ?? ART.moods.idle;
    const context = canvas.current?.getContext("2d");
    if (!context || !animation) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let index = 0;
    const draw = () => {
      context.clearRect(0, 0, ART.width * scale, ART.height * scale);
      animation.frames[index].forEach((line, row) => {
        [...line].forEach((char, col) => {
          const color = ART.palette[char];
          if (!color) return;
          context.fillStyle = color;
          context.fillRect(col * scale, row * scale, scale, scale);
        });
      });
    };
    draw();
    if (reduce || animation.frames.length < 2) return;
    // Só no ritmo do humor (1 a 6 quadros por segundo), nada de requestAnimationFrame.
    const timer = window.setInterval(() => { index = (index + 1) % animation.frames.length; draw(); }, 1000 / animation.fps);
    return () => window.clearInterval(timer);
  }, [mood, scale]);
  return <canvas ref={canvas} width={ART.width * scale} height={ART.height * scale} aria-hidden style={{ imageRendering: "pixelated" }} />;
}
