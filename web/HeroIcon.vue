<template>
    <div aria-hidden="true">
        <img
            class="heroIconBackground"
            :src="iconBackground"
            alt=""
            decoding="sync"
            fetchpriority="high"
        />
        <div class="heroIconArtwork">
            <div
                class="heroIconMaskGroup"
                :style="{ maskImage: `url('${iconMask}')`, WebkitMaskImage: `url('${iconMask}')` }"
            >
                <img
                    class="heroIconBlendBackdrop"
                    :src="iconBackground"
                    alt=""
                    decoding="sync"
                    fetchpriority="high"
                />
                <div class="heroIconGlow heroIconGlow--top">
                    <div class="heroIconGlowRotated">
                        <img :src="iconGlowTop" alt="" />
                    </div>
                </div>
                <div class="heroIconGlow heroIconGlow--bottom">
                    <div class="heroIconGlowRotated">
                        <img :src="iconGlowBottom" alt="" />
                    </div>
                </div>
                <div class="heroIconPepperMotion">
                    <div class="heroIconPepper">
                        <img
                            :src="iconPepper"
                            alt=""
                            decoding="sync"
                            fetchpriority="high"
                        />
                    </div>
                </div>
            </div>
        </div>
    </div>
</template>

<script lang="ts">
import { defineComponent } from "vue"
import iconBackground from "./assets/hero/icon-background.png"
import iconGlowBottom from "./assets/hero/icon-glow-bottom.svg"
import iconGlowTop from "./assets/hero/icon-glow-top.svg"
import iconMask from "./assets/hero/icon-mask.svg"
import iconPepper from "./assets/hero/icon-pepper.png"

export default defineComponent({
    name: "HeroIcon",
    props: { src: String },
    data() {
        return {
            iconBackground,
            iconGlowBottom,
            iconGlowTop,
            iconMask,
            iconPepper,
        }
    },
})
</script>

<style>
.heroIcon {
    position: relative;
    overflow: hidden;
    border-radius: 0;
}

/* 原画板 248px，按 QPage `.heroIcon` 在各断点的边长等比缩放 */
.heroIconArtwork {
    position: absolute;
    inset: 0;
    width: 248px;
    height: 248px;
    transform: scale(calc(256 / 248));
    transform-origin: 0 0;
}

@media (max-width: 860px) {
    .heroIconArtwork {
        transform: scale(calc(120 / 248));
    }
}

@media (max-width: 520px) {
    .heroIconArtwork {
        transform: scale(calc(96 / 248));
    }
}

.heroIconBackground {
    width: 100%;
    height: 100%;
    object-fit: cover;
}

.heroIconMaskGroup {
    position: absolute;
    top: 24.21875px;
    left: 24.21875px;
    width: 199.5625px;
    height: 199.5625px;
    isolation: isolate;
    -webkit-mask-mode: alpha;
    mask-mode: alpha;
    -webkit-mask-position: 0 0;
    mask-position: 0 0;
    -webkit-mask-repeat: no-repeat;
    mask-repeat: no-repeat;
    -webkit-mask-size: 199.5625px 199.5625px;
    mask-size: 199.5625px 199.5625px;
}

.heroIconBlendBackdrop {
    position: absolute;
    z-index: 0;
    top: -24.21875px;
    left: -24.21875px;
    width: 248px;
    height: 248px;
    max-width: none;
    object-fit: cover;
    pointer-events: none;
}

.heroIconGlow {
    position: absolute;
    z-index: 1;
    display: flex;
    width: 262.352px;
    height: 260.977px;
    align-items: center;
    justify-content: center;
    mix-blend-mode: multiply;
}

.heroIconGlowRotated {
    position: relative;
    width: 127.633px;
    height: 242.43px;
    transform: rotate(45.49deg);
}

.heroIconGlowRotated img {
    position: absolute;
    top: -29.066px;
    left: -29.063px;
    width: 185.758px;
    height: 300.555px;
    max-width: none;
}

.heroIconGlow--top {
    top: -111.719px;
    left: -105.379px;
}

.heroIconGlow--bottom {
    top: 35.359px;
    left: 10.414px;
}

.heroIconPepperMotion {
    position: absolute;
    z-index: 2;
    top: 35.359px;
    left: 20.586px;
    display: flex;
    width: 238.968px;
    height: 238.968px;
    align-items: center;
    justify-content: center;
    will-change: transform;
    transform: translate(83.797px, 100.266px);
    animation: heroPepper 8s infinite;
}

.heroIconPepper {
    width: 172.434px;
    height: 172.434px;
    filter: drop-shadow(-16px -7px 37px rgba(10, 46, 12, 0.62));
    transform: rotate(-33.51deg);
}

.heroIconPepper img {
    width: 100%;
    height: 100%;
    object-fit: cover;
}

/* 对齐 web-old motion：4s 正向 + 4s 反向，中间点 14.77% */
@keyframes heroPepper {
    0% {
        transform: translate(83.797px, 100.266px);
        animation-timing-function: linear;
    }
    7.385% {
        transform: translate(44.58px, 42.501px);
        animation-timing-function: cubic-bezier(0, 0, 0, 0.947);
    }
    50% {
        transform: translate(12.109px, -5.328px);
        animation-timing-function: cubic-bezier(1, 0.053, 1, 1);
    }
    92.615% {
        transform: translate(44.58px, 42.501px);
        animation-timing-function: linear;
    }
    100% {
        transform: translate(83.797px, 100.266px);
    }
}

@media (prefers-reduced-motion: reduce) {
    .heroIconPepperMotion {
        animation: none;
        transform: translate(12.109px, -5.328px);
    }
}
</style>
