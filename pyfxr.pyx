#cython: language_level=3

from libc.stdint cimport int16_t, uint32_t
from libc.math cimport sin, pi, floor
from libc.stdlib cimport rand

from cpython.mem cimport PyMem_Malloc, PyMem_Free


cdef float AMPLITUDE = (1 << 15) - 1


cdef int16_t samp(float v) nogil:
    """Convert a float in [-1, 1] to an int16_t sample."""
    return <int16_t> floor(v * AMPLITUDE)


cdef class Waveform:
    cdef int16_t[1024] waveform

    def __init__(self, gen):
        cdef int i
        for i, val in enumerate(gen):
            self.waveform[i] = samp(val)
            if i == 1023:
                return

        if i != 1023:
            raise ValueError(
                "Waveform generator generated too few values."
            )

    @staticmethod
    def sine():
        cdef Waveform w
        cdef size_t i
        w = Waveform.__new__(Waveform)
        with nogil:
            for i in range(1024):
                w.waveform[i] = samp(
                    sin(pi * 2.0 * i / 1023.0)
                )
        return w

    @staticmethod
    def triangle():
        cdef Waveform w
        cdef size_t i
        cdef float v
        w = Waveform.__new__(Waveform)
        with nogil:
            for i in range(1024):
                if i < 256:
                    v = i / 256
                elif i < 768:
                    v = 1.0 - (i - 255) / 256
                else:
                    v = (i - 768) / 256 - 1.0
                w.waveform[i] = samp(v)
        return w

    @staticmethod
    def saw():
        cdef Waveform w
        cdef size_t i
        cdef float v
        w = Waveform.__new__(Waveform)
        with nogil:
            for i in range(1024):
                w.waveform[i] = samp(i / 512.0 - 1.0)
        return w

    @staticmethod
    def square():
        """Generate a square-wave waveform."""
        cdef Waveform w
        cdef size_t i
        cdef float v
        w = Waveform.__new__(Waveform)
        with nogil:
            for i in range(512):
                w.waveform[i] = -32768
            for i in range(512, 1024):
                w.waveform[i] = 32767
        return w

    def __getbuffer__(self, Py_buffer *buffer, int flags):
        cdef Py_ssize_t itemsize = sizeof(int16_t)

        buffer.buf = self.waveform
        buffer.format = 'h'                     # double
        buffer.internal = NULL                  # see References
        buffer.itemsize = itemsize
        buffer.len = sizeof(self.waveform)
        buffer.ndim = 1
        buffer.obj = self
        buffer.readonly = 0
        buffer.shape = NULL
        buffer.strides = NULL
        buffer.suboffsets = NULL                # for pointer arrays only

    def __releasebuffer__(self, Py_buffer *buffer):
        pass


cdef class SoundBuffer:
    cdef size_t n_samples
    cdef int16_t *samples

    def __cinit__(self, size_t n_samples):
        self.samples = <int16_t*> PyMem_Malloc(n_samples * sizeof(int16_t))
        self.n_samples = n_samples
        if not self.samples:
            raise MemoryError()
        for i in range(n_samples):
            self.samples[i] = 0

    def __dealloc__(self):
        PyMem_Free(self.samples)

    def __len__(self):
        return self.n_samples

    def __getitem__(self, ssize_t i):
        if i >= 0:
            if i >= self.n_samples:
                raise IndexError("index out of range")
        else:
            i = self.n_samples + i
            if i < 0:
                raise IndexError("index out of range")
        return self.samples[i]

    @property
    def duration(SoundBuffer self):
        return self.n_samples / <float> SAMPLE_RATE

    def __getbuffer__(self, Py_buffer *buffer, int flags):
        cdef Py_ssize_t itemsize = sizeof(int16_t)

        buffer.buf = self.samples
        buffer.format = 'h'                     # double
        buffer.internal = NULL                  # see References
        buffer.itemsize = itemsize
        buffer.len = sizeof(int16_t) * self.n_samples
        buffer.ndim = 1
        buffer.obj = self
        buffer.readonly = 0
        buffer.shape = NULL
        buffer.strides = NULL
        buffer.suboffsets = NULL                # for pointer arrays only

    def __releasebuffer__(self, Py_buffer *buffer):
        pass


cdef float SAMPLE_RATE = 44100


def tone(
    Waveform waveform,
    double pitch=440.0,  # Hz, default = A
    uint32_t attack=4000,
    uint32_t decay=4000,
    uint32_t sustain=30000,
    uint32_t release=20000
):
    cdef uint32_t time = 0
    cdef size_t n_samples, i
    cdef SoundBuffer t
    cdef int16_t *samples
    cdef uint32_t omega   # angular velocity
    cdef int16_t v
    cdef float amplitude

    # time and omega will be fixed point where time in real samples
    # is time >> 10

    time = 0
    omega = <uint32_t> (pitch * 1024 / SAMPLE_RATE * 1024)

    n_samples = attack + decay + sustain + release
    t = SoundBuffer(n_samples)
    samples = t.samples

    with nogil:
        for i in range(n_samples):
            time += omega
            v = waveform.waveform[(time >> 10) & 0x3ff]

            if i < attack:
                amplitude = (i / <float> attack)
            elif i < attack + decay:
                amplitude = (1.0 - (i - attack) / <float> decay * 0.3)
            elif i < attack + decay + sustain:
                amplitude = 0.7
            else:
                amplitude = (n_samples - i) / release * 0.7

            samples[i] = <int16_t> (amplitude * v)

    return t


cdef reset_sample(
    float p_base_freq,
    float p_freq_limit,
    float p_freq_ramp,
    float p_freq_dramp,
    float p_duty,
    float p_duty_ramp,
    float p_arp_mod,
    float p_arp_speed,
    double *fperiod,
    int *period,
    double *fmaxperiod,
    double *fslide,
    double *fdslide,
    float *square_duty,
    float *square_slide,
    double *arp_mod,
    int *arp_time,
    int *arp_limit
):
    fperiod[0] = 100.0 / (p_base_freq * p_base_freq + 0.001)
    period[0] = <int> fperiod[0]
    fmaxperiod[0] = 100.0 / (p_freq_limit * p_freq_limit + 0.001)
    fslide[0] = 1.0 - p_freq_ramp ** 3.0 * 0.01
    fdslide[0] = p_freq_dramp ** 3.0 * -0.000001;
    square_duty[0] = 0.5 - p_duty * 0.5;
    square_slide[0] = p_duty_ramp * -0.00005;
    if p_arp_mod >= 0.0:
        arp_mod[0] = 1.0 - p_arp_mod ** 2.0 * 0.9
    else:
        arp_mod[0] = 1.0 + p_arp_mod ** 2.0 * 10.0
    arp_time[0] = 0
    arp_limit[0] = <int> ((1.0 - p_arp_speed) ** 2.0) * 20000 + 32
    if p_arp_speed == 1.0:
        arp_limit[0] = 0


from cython cimport floating


cdef clamp(floating *v, floating min, floating max):
    """Clamp the given value v to between min and max."""
    if v[0] < min:
        v[0] = min
    elif v[0] > max:
        v[0] = max


cdef fill_noise(float *noise_buffer):
    for i in range(32):
        noise_buffer[i] = frnd(2.0) - 1.0;


cdef frnd(float range_):
    return <float> (rand() % 10001) / 10000 * range_


def sfx(
    int wave_type,
    float p_base_freq,
    float p_freq_limit,
    float p_freq_ramp,
    float p_freq_dramp,
    float p_duty,
    float p_duty_ramp,
    float p_vib_strength,
    float p_vib_speed,
    float p_vib_delay,
    float p_env_attack,
    float p_env_sustain,
    float p_env_decay,
    float p_env_punch,
    float p_lpf_resonance,
    float p_lpf_freq,
    float p_lpf_ramp,
    float p_hpf_freq,
    float p_hpf_ramp,
    float p_pha_offset,
    float p_pha_ramp,
    float p_repeat_speed,
    float p_arp_speed,
    float p_arp_mod,
):
    cdef int phase=0, period, env_stage, env_time, iphase, ipp
    cdef double fperiod, fmaxperiod, fslide, fdslide, arp_mod
    cdef float square_duty, square_slide, env_vol, fphase, fdphase
    cdef int env_length[3]
    cdef float phaser_buffer[1024]
    cdef float noise_buffer[32]
    cdef float fltp = 0.0, fltdp = 0.0, fltphp = 0.0
    cdef float fltw, fltw_d, fltdmp, flthp, flthp_d, vib_phase, vib_speed, vib_amp
    cdef int rep_time, rep_limit, arp_time, arp_limit
    cdef float rfperiod
    cdef float ssample = 0.0, sample = 0.0, fp, pp
    cdef int si, ni

    reset_sample(
        p_base_freq,
        p_freq_limit,
        p_freq_ramp,
        p_freq_dramp,
        p_duty,
        p_duty_ramp,
        p_arp_mod,
        p_arp_speed,

        &fperiod,
        &period,
        &fmaxperiod,
        &fslide,
        &fdslide,
        &square_duty,
        &square_slide,
        &arp_mod,
        &arp_time,
        &arp_limit
    )

    # reset filter
    fltw = 0.1 * p_lpf_freq ** 3.0
    fltw_d = 1.0 + p_lpf_ramp * 0.0001
    fltdmp = 5.0 / (1.0 + p_lpf_resonance ** 2.0 * 20.0) * (0.01 + fltw)
    clamp(&fltdmp, 0.0, 0.8)

    flthp = 0.1 * p_hpf_freq ** 2.0
    flthp_d = 1.0 + p_hpf_ramp * 0.0003;

    # reset vibrato
    vib_phase = 0.0;
    vib_speed = p_vib_speed ** 2.0 * 0.01;
    vib_amp = p_vib_strength * 0.5;

    # reset envelope
    env_vol = 0.0;
    env_stage = 0;
    env_time = 0;
    env_length[0] = <int> (p_env_attack * p_env_attack * 100000.0);
    env_length[1] = <int> (p_env_sustain * p_env_sustain * 100000.0);
    env_length[2] = <int> (p_env_decay * p_env_decay * 100000.0);

    cdef size_t n_samples = env_length[0] + env_length[1] + env_length[2];
    cdef SoundBuffer s = SoundBuffer(n_samples)

    fphase = p_pha_offset ** 2.0 * 1020.0;
    if p_pha_offset < 0.0:
        fphase = -fphase
    fdphase = p_pha_ramp ** 2.0
    if p_pha_ramp < 0.0:
        fdphase = -fdphase
    iphase = abs(<int> fphase)
    ipp = 0
    for i in range(1024):
        phaser_buffer[i] = 0.0

    # Fill noise buffer
    fill_noise(noise_buffer)

    # reset repeats
    rep_time = 0
    rep_limit = <int> ((1.0 - p_repeat_speed) ** 2.0) * 20000 + 32
    if p_repeat_speed == 0.0:
        rep_limit = 0

    for i in range(n_samples):
        rep_time += 1

        if rep_limit and rep_time >= rep_limit:
            rep_time = 0
            reset_sample(
                p_base_freq,
                p_freq_limit,
                p_freq_ramp,
                p_freq_dramp,
                p_duty,
                p_duty_ramp,
                p_arp_mod,
                p_arp_speed,

                &fperiod,
                &period,
                &fmaxperiod,
                &fslide,
                &fdslide,
                &square_duty,
                &square_slide,
                &arp_mod,
                &arp_time,
                &arp_limit
            )

        # frequency envelopes/arpeggios
        arp_time += 1
        if 0 != arp_limit < arp_time:
            arp_limit=0
            fperiod *= arp_mod

        fslide += fdslide
        fperiod *= fslide
        if fperiod > fmaxperiod:
            fperiod = fmaxperiod
            if p_freq_limit > 0.0:
                break

        rfperiod = fperiod
        if vib_amp > 0.0:
            vib_phase += vib_speed
            rfperiod = fperiod * (1.0 + sin(vib_phase) * vib_amp)

        period = <int> rfperiod
        if period < 8:
            period = 8
        square_duty += square_slide
        clamp(&square_duty, 0.0, 0.5)

        # volume envelope
        env_time += 1
        if env_time > env_length[env_stage]:
            env_time = 0
            env_stage += 1
            if env_stage == 3:
                break

        if env_stage == 0:
            env_vol = <float> env_time / env_length[0]
        elif env_stage == 1:
            # TODO: what's this pow doing?
            env_vol = 1.0 + pow(1.0 - <float> env_time / env_length[1], 1.0) * 2.0 * p_env_punch
        elif env_stage == 2:
            env_vol = 1.0 - <float> env_time / env_length[2]

        # phaser step
        fphase += fdphase;
        iphase = abs(<int> fphase)
        if iphase > 1023:
            iphase = 1023

        if flthp_d != 0.0:
            flthp *= flthp_d
            clamp(&flthp, 0.00001, 0.1)

        ssample = 0.0
        for si in range(8):  # 8x supersampling
            sample = 0.0
            phase += 1
            if phase >= period:
                phase %= period
                if wave_type == 3:
                    fill_noise(noise_buffer)

            # base waveform
            fp = <float> phase / period;
            if wave_type == 0:  # square
                sample = 0.5 if fp < square_duty else -0.5
            elif wave_type == 1:  # sawtooth
                sample = 1.0 - fp * 2
            elif wave_type == 2:  # sine
                sample = <float> sin(fp * 2 * pi);
            elif wave_type == 3:  # noise
                sample = noise_buffer[<size_t> (phase * 32 / period)]

            # lp filter
            pp = fltp
            fltw *= fltw_d
            clamp(&fltw, 0.0, 0.1)
            if p_lpf_freq != 1.0:
                fltdp += (sample - fltp) * fltw;
                fltdp -= fltdp * fltdmp;
                fltp += fltdp
            else:
                fltp = sample
                fltdp = 0.0

            # hp filter
            fltphp += fltp - pp;
            fltphp -= fltphp * flthp;
            sample = fltphp;

            # phaser
            phaser_buffer[ipp & 1023] = sample
            sample += phaser_buffer[(ipp - iphase + 1024) & 1023]
            ipp = (ipp + 1) & 1023

            # final accumulation and envelope application
            ssample += sample * env_vol

        ssample /= 8
        clamp(&ssample, -1.0, 1.0)
        s.samples[i] = samp(ssample)
    return s
